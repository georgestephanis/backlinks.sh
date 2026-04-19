#!/usr/bin/env bash
set -euo pipefail

# Queries the Common Crawl CDX index for HTML pages on every domain
# that links to the target domain. Requires the domain-level graph
# to already be cached (run backlinks.sh first).
#
# Output is JSONL (one CDX record per line) suitable for piping into
# link-details.sh.

DOMAIN="example.com"

usage() {
  cat <<'EOF'
Usage: cdx-pages.sh [options] [domain]

Queries the Common Crawl CDX index for crawled HTML pages on all
domains that link to the given domain. Requires the domain-level
graph to be cached first (run backlinks.sh).

Output is JSONL, one CDX record per line. Pipe into link-details.sh
to extract anchor text and rel attributes from those pages.

Arguments:
  domain             Target domain (default: example.com)

Options:
  -h, --help         Show this help message and exit

Environment:
  CC_RELEASE         Common Crawl release (default: cc-main-2026-jan-feb-mar)
  CDX_CRAWL          Override which CDX crawl(s) to query, newline-separated
                     (e.g. CC-MAIN-2026-04). Defaults to all crawls in the release.
  CDX_LIMIT          Max pages to fetch per domain per crawl (default: 500)
  CDX_MAX_DOMAINS    Only query the top N linking domains by host count (default: all)

Cache:
  ~/.cache/cc-backlinks/<release>/cdx/<domain>/

Examples:
  ./backlinks.sh example.com          # cache the domain graph first
  ./cdx-pages.sh example.com          # find CDX pages on linking domains
  ./cdx-pages.sh example.com | ./link-details.sh example.com
EOF
}

for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    -*) echo "error: unknown option: $arg" >&2; exit 1 ;;
    *) DOMAIN="$arg" ;;
  esac
done

# Animate a - \ | / spinner on stderr while a background PID is running,
# then clear the line so the caller can print a final status.
spin() {
  local pid=$1 msg="${2:-}"
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r  %s %s' "${_SPIN_FRAMES:$(( i % 4 )):1}" "$msg" >&2
    sleep 0.1
    i=$(( i + 1 ))
  done
  printf '\r%80s\r' '' >&2   # clear the spinner line
}
_SPIN_FRAMES='-\|/'

RELEASE="${CC_RELEASE:-cc-main-2026-jan-feb-mar}"
LIMIT="${CDX_LIMIT:-500}"
MAX_DOMAINS="${CDX_MAX_DOMAINS:-0}"   # 0 = no limit
CACHE="${HOME}/.cache/cc-backlinks/${RELEASE}"
CDX_CACHE="${CACHE}/cdx/${DOMAIN}"
GRAPHINFO="${CACHE}/.graphinfo.json"

mkdir -p "$CDX_CACHE"

# --- Step 1: Resolve CDX crawl IDs for this release ---
# graphinfo.json maps release IDs to their constituent crawl IDs.
# CDX_CRAWL env var overrides this lookup entirely.

if [[ -n "${CDX_CRAWL:-}" ]]; then
  CRAWL_IDS="$CDX_CRAWL"
else
  if [[ ! -f "$GRAPHINFO" ]]; then
    echo ">> fetching release index ..." >&2
    curl -sL "https://index.commoncrawl.org/graphinfo.json" -o "$GRAPHINFO"
  fi

  # graphinfo.json is a JSON array; each entry has "id" and "crawls" fields.
  CRAWL_IDS=$(python3 -c '
import json, sys
release = sys.argv[1]
with open(sys.argv[2]) as f:
    data = json.load(f)
for entry in data:
    if entry.get("id") == release:
        print("\n".join(entry.get("crawls", [])))
        sys.exit(0)
sys.exit(1)
' "$RELEASE" "$GRAPHINFO") || {
    echo "error: release '${RELEASE}' not found in graphinfo.json" >&2
    echo "       Set CDX_CRAWL=CC-MAIN-YYYY-WW to specify a crawl manually." >&2
    exit 1
  }
fi

echo ">> crawl(s): $(echo "$CRAWL_IDS" | tr '\n' ' ')" >&2

# --- Step 2: Get linking domains from the cached domain graph ---

VERTICES="${CACHE}/domain-vertices.txt.gz"
EDGES="${CACHE}/domain-edges.txt.gz"

if [[ ! -f "$VERTICES" || ! -f "$EDGES" ]]; then
  echo "error: domain graph not cached. Run: ./backlinks.sh ${DOMAIN}" >&2
  exit 1
fi

REV_DOMAIN=$(awk -F. '{for(i=NF;i>0;i--) printf "%s%s", $i, (i>1?".":"")}' <<<"$DOMAIN")
DOMAINS_CACHE="${CDX_CACHE}/.linking-domains"

if [[ ! -f "$DOMAINS_CACHE" ]]; then
  echo ">> finding domains linking to ${DOMAIN} ..." >&2
  # Run DuckDB in the background so we can show a spinner while it scans
  # the full edges file (~16 GB). Output goes directly to the cache file.
  duckdb <<SQL > "$DOMAINS_CACHE" &
.mode list
.headers off
WITH vertices AS (
  SELECT * FROM read_csv('${VERTICES}', delim='\t', header=false,
    columns={'id':'BIGINT','rev_domain':'VARCHAR','num_hosts':'BIGINT'})
),
target AS (
  SELECT id FROM vertices WHERE rev_domain = '${REV_DOMAIN}'
),
inbound AS (
  SELECT from_id FROM read_csv('${EDGES}', delim='\t', header=false,
    columns={'from_id':'BIGINT','to_id':'BIGINT'})
  WHERE to_id = (SELECT id FROM target)
)
SELECT array_to_string(list_reverse(string_split(v.rev_domain, '.')), '.') AS domain
FROM inbound i
JOIN vertices v ON v.id = i.from_id
ORDER BY v.num_hosts DESC, domain;
SQL
  DDB_PID=$!
  spin "$DDB_PID" "scanning edges (this takes several minutes on first run)..."
  wait "$DDB_PID"
  printf '   found %s linking domain(s)\n' "$(wc -l < "$DOMAINS_CACHE" | tr -d ' ')" >&2
fi

TOTAL=$(wc -l < "$DOMAINS_CACHE" | tr -d ' ')
[[ "${MAX_DOMAINS}" -gt 0 && "${MAX_DOMAINS}" -lt "$TOTAL" ]] && TOTAL="$MAX_DOMAINS"
CRAWL_TOTAL=$(printf '%s\n' "$CRAWL_IDS" | grep -c .)
echo ">> querying CDX for pages on ${TOTAL} linking domain(s) ..." >&2

# --- Step 3: Query CDX for HTML pages on each linking domain ---
# Results cached per domain so re-runs are instant.
# matchType=domain matches the root domain and all subdomains.
# A completion line is printed for each domain so progress is visible.

DONE=0
while IFS= read -r source_domain; do
  [[ "${MAX_DOMAINS}" -gt 0 && "$DONE" -ge "${MAX_DOMAINS}" ]] && break
  DONE=$(( DONE + 1 ))

  PAGE_CACHE="${CDX_CACHE}/${source_domain}.jsonl"
  if [[ -f "$PAGE_CACHE" ]]; then
    PAGE_COUNT=$(wc -l < "$PAGE_CACHE" | tr -d ' ')
    printf '  [%d/%d] %-50s  %4d pages (cached)\n' "$DONE" "$TOTAL" "$source_domain" "$PAGE_COUNT" >&2
    cat "$PAGE_CACHE"
    continue
  fi

  {
    _n=0
    while IFS= read -r crawl_id; do
      [[ -z "$crawl_id" ]] && continue
      _n=$(( _n + 1 ))
      printf '\r  [%d/%d] %-40s  querying crawl %d/%d (%s)%10s' \
        "$DONE" "$TOTAL" "$source_domain" "$_n" "$CRAWL_TOTAL" "$crawl_id" "" >&2
      curl -sGf "https://index.commoncrawl.org/${crawl_id}-index" \
        --data-urlencode "url=${source_domain}" \
        --data-urlencode "matchType=domain" \
        --data-urlencode "output=json" \
        --data-urlencode "fl=url,timestamp,filename,offset,length,digest,status,mime-detected" \
        --data-urlencode "filter=status:200" \
        --data-urlencode "filter=mime-detected:text/html" \
        --data-urlencode "limit=${LIMIT}" || true
    done <<<"$CRAWL_IDS"
  } | grep -v '^$' | tee "$PAGE_CACHE"

  PAGE_COUNT=$(wc -l < "$PAGE_CACHE" | tr -d ' ')
  printf '\r  [%d/%d] %-50s  %4d pages\n' "$DONE" "$TOTAL" "$source_domain" "$PAGE_COUNT" >&2

done < "$DOMAINS_CACHE"
