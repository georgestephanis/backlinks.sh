#!/usr/bin/env bash
set -euo pipefail

DOMAIN="example.com"
HOST_MODE=false
CACHE_INFO=false

usage() {
  cat <<'EOF'
Usage: backlinks.sh [options] [domain]

Find all domains or hosts that link to a given domain using the
Common Crawl hyperlink graph. Data is downloaded and cached locally
on first run; subsequent runs skip already-downloaded files.

Arguments:
  domain          Target domain to find backlinks for (default: example.com)

Options:
  --host          Use the host-level graph instead of domain-level.
                  Results show individual subdomains (e.g. blog.site.com)
                  rather than just top-level domains. Downloads ~41 GB of
                  sharded data on first run.
  --cache-info    Show local cache contents, disk usage, and instructions
                  for clearing or switching to a newer release. Exits
                  without querying.
  -h, --help      Show this help message and exit

Environment:
  CC_RELEASE      Common Crawl release to query
                  (default: cc-main-2026-jan-feb-mar)

Cache:
  ~/.cache/cc-backlinks/<release>/

Examples:
  backlinks.sh example.com
  backlinks.sh --host example.com
  CC_RELEASE=cc-main-2025-oct-nov-dec backlinks.sh example.com

Data:   https://commoncrawl.org/web-graphs
Needs:  duckdb (brew install duckdb), curl, awk
EOF
}

cache_info() {
  local release="${CC_RELEASE:-cc-main-2026-jan-feb-mar}"
  local base="${HOME}/.cache/cc-backlinks"

  printf 'Cache: %s\n' "$base"
  if [[ ! -d "$base" ]]; then
    printf 'Total: (no cache found)\n\n'
  else
    printf 'Total: %s\n\n' "$(du -sh "$base" | cut -f1)"

    local found_any=false
    for rel_dir in "${base}"/*/; do
      [[ -d "$rel_dir" ]] || continue
      found_any=true
      local rel
      rel=$(basename "$rel_dir")
      [[ "$rel" == "$release" ]] \
        && printf '  %s  [active]\n' "$rel" \
        || printf '  %s\n' "$rel"

      # Domain-level single files
      local dv="${rel_dir}domain-vertices.txt.gz"
      local de="${rel_dir}domain-edges.txt.gz"
      [[ -f "$dv" ]] \
        && printf '    domain/vertices   %s\n' "$(du -sh "$dv" | cut -f1)" \
        || printf '    domain/vertices   not downloaded\n'
      [[ -f "$de" ]] \
        && printf '    domain/edges      %s\n' "$(du -sh "$de" | cut -f1)" \
        || printf '    domain/edges      not downloaded\n'

      # Host-level shards: read shard totals from cached manifests if available,
      # fall back to the known counts for the current dataset format.
      local vm="${rel_dir}host/.vertices-manifest"
      local em="${rel_dir}host/.edges-manifest"
      local hv="${rel_dir}host/vertices"
      local he="${rel_dir}host/edges"
      local v_total=48 e_total=192
      [[ -f "$vm" ]] && v_total=$(wc -l < "$vm" | tr -d ' ')
      [[ -f "$em" ]] && e_total=$(wc -l < "$em" | tr -d ' ')

      # Count downloaded shards without erroring if the directory/glob is empty.
      local v_count e_count
      v_count=$(shopt -s nullglob; arr=("${hv}"/*.gz); echo "${#arr[@]}")
      e_count=$(shopt -s nullglob; arr=("${he}"/*.gz); echo "${#arr[@]}")

      if [[ "$v_count" -gt 0 ]]; then
        printf '    host/vertices     %d/%d shards, %s\n' "$v_count" "$v_total" "$(du -sh "$hv" | cut -f1)"
      else
        printf '    host/vertices     not downloaded\n'
      fi
      if [[ "$e_count" -gt 0 ]]; then
        printf '    host/edges        %d/%d shards, %s\n' "$e_count" "$e_total" "$(du -sh "$he" | cut -f1)"
      else
        printf '    host/edges        not downloaded\n'
      fi

      printf '    subtotal          %s\n\n' "$(du -sh "$rel_dir" | cut -f1)"
    done

    $found_any || printf '  (no releases cached)\n\n'
  fi

  printf 'To clear one release:\n  rm -rf %s/<release>\n\n' "$base"
  printf 'To clear everything:\n  rm -rf %s\n\n' "$base"
  printf 'To switch to a newer release, set CC_RELEASE before running:\n'
  printf '  CC_RELEASE=cc-main-YYYY-mon-mon-mon ./backlinks.sh [domain]\n\n'
  printf 'Browse available releases: https://commoncrawl.org/web-graphs\n'
}

for arg in "$@"; do
  case "$arg" in
    --host)       HOST_MODE=true ;;
    --cache-info) CACHE_INFO=true ;;
    -h|--help)    usage; exit 0 ;;
    -*) echo "error: unknown option: $arg" >&2; exit 1 ;;
    *) DOMAIN="$arg" ;;
  esac
done

if $CACHE_INFO; then cache_info; exit 0; fi

RELEASE="${CC_RELEASE:-cc-main-2026-jan-feb-mar}"
CACHE="${HOME}/.cache/cc-backlinks/${RELEASE}"
BASE="https://data.commoncrawl.org/projects/hyperlinkgraph/${RELEASE}"
CC_BASE="https://data.commoncrawl.org"

mkdir -p "$CACHE"

if ! command -v duckdb >/dev/null; then
  echo "error: duckdb not installed. Run: brew install duckdb" >&2
  exit 1
fi

# Reverse domain: roots.io -> io.roots
REV_DOMAIN=$(awk -F. '{for(i=NF;i>0;i--) printf "%s%s", $i, (i>1?".":"")}' <<<"$DOMAIN")

# Draw a [####----] done/total label progress bar in place.
draw_progress() {
  local done=$1 total=$2 label="$3"
  local width=40 filled empty filled_s empty_s
  filled=$(( done * width / total ))
  empty=$(( width - filled ))
  # '%*s' prints an empty string padded to $filled width; replacing spaces gives us $filled '#' chars.
  printf -v filled_s '%*s' "$filled" ''
  printf -v empty_s  '%*s' "$empty"  ''
  printf '\r  [%s%s] %d/%d %s' \
    "${filled_s// /#}" "${empty_s// /-}" \
    "$done" "$total" "$label" >&2
}

download() {
  local url="$1" dest="$2"
  if [[ -f "$dest" ]]; then return; fi
  echo ">> downloading $(basename "$dest") ..." >&2
  curl -L --fail -C - --progress-bar -o "$dest" "$url"
}

if ! $HOST_MODE; then
  # Domain-level (default)
  VERTICES="${CACHE}/domain-vertices.txt.gz"
  EDGES="${CACHE}/domain-edges.txt.gz"

  download "${BASE}/domain/${RELEASE}-domain-vertices.txt.gz" "$VERTICES"
  download "${BASE}/domain/${RELEASE}-domain-edges.txt.gz"    "$EDGES"

  echo ">> querying backlinks to ${DOMAIN} (reversed: ${REV_DOMAIN}) ..." >&2
  echo ">> first run scans ~16 GB of gzipped edges; expect several minutes" >&2

  duckdb <<SQL
.mode box
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
SELECT
  array_to_string(list_reverse(string_split(v.rev_domain, '.')), '.') AS linking_domain,
  v.num_hosts
FROM inbound i
JOIN vertices v ON v.id = i.from_id
ORDER BY v.num_hosts DESC, linking_domain;
SQL
  exit 0
fi

# Host-level (--host flag)
# Data is sharded: .paths.gz files are manifests listing the actual shard paths.
# Vertices: 48 shards (~2 GB total), edges: 192 shards (~39 GB total).
HOST_CACHE="${CACHE}/host"
mkdir -p "${HOST_CACHE}/vertices" "${HOST_CACHE}/edges"

download_shards() {
  local manifest_url="$1" dest_dir="$2" manifest="$3"

  if [[ ! -f "$manifest" ]]; then
    echo ">> fetching shard manifest: $(basename "$manifest_url") ..." >&2
    curl -sL "$manifest_url" | gunzip > "$manifest"
  fi

  local -a pending=()
  while IFS= read -r path; do
    local dest="${dest_dir}/$(basename "$path")"
    [[ -f "$dest" ]] || pending+=("${CC_BASE}/${path}" "$dest")
  done < "$manifest"

  [[ ${#pending[@]} -eq 0 ]] && return

  local total=$(( ${#pending[@]} / 2 ))
  local label
  label="$(basename "$dest_dir") shards"
  echo ">> downloading ${total} ${label} (8 parallel) ..." >&2

  # Each completed curl appends one byte to a temp file; we count bytes for progress.
  local progress_file
  progress_file=$(mktemp)

  # pending is interleaved url/dest pairs; xargs feeds them two at a time as $1 and $2.
  # _ is a dummy $0. \$1/\$2 are escaped so the *inner* bash expands them from xargs args;
  # $progress_file is unescaped so the *outer* shell embeds the literal path now.
  printf '%s\n' "${pending[@]}" | \
    xargs -P8 -n2 bash -c "curl -sL --fail -o \"\$2\" \"\$1\" && printf x >> \"$progress_file\"" _ &
  local bg_pid=$!

  local done_count=0
  draw_progress "$done_count" "$total" "$label"
  # kill -0 sends no signal; it just checks whether the process is still alive.
  while kill -0 "$bg_pid" 2>/dev/null; do
    done_count=$(wc -c < "$progress_file" | tr -d ' ')
    draw_progress "$done_count" "$total" "$label"
    sleep 0.2
  done
  wait "$bg_pid"
  done_count=$(wc -c < "$progress_file" | tr -d ' ')
  draw_progress "$done_count" "$total" "$label"
  printf '\n' >&2
  rm -f "$progress_file"
}

download_shards \
  "${BASE}/host/${RELEASE}-host-vertices.paths.gz" \
  "${HOST_CACHE}/vertices" \
  "${HOST_CACHE}/.vertices-manifest"

download_shards \
  "${BASE}/host/${RELEASE}-host-edges.paths.gz" \
  "${HOST_CACHE}/edges" \
  "${HOST_CACHE}/.edges-manifest"

echo ">> querying host-level backlinks to ${DOMAIN} ..." >&2
echo ">> first run scans ~39 GB of gzipped edge shards; expect many minutes" >&2

duckdb <<SQL
.mode box
WITH vertices AS (
  SELECT * FROM read_csv('${HOST_CACHE}/vertices/*.gz', delim='\t', header=false,
    columns={'id':'BIGINT','rev_host':'VARCHAR'})
),
target AS (
  SELECT id FROM vertices
  -- trailing dot ensures LIKE matches only subdomains, not unrelated domains sharing a prefix
  WHERE rev_host = '${REV_DOMAIN}' OR rev_host LIKE '${REV_DOMAIN}.%'
),
inbound AS (
  SELECT from_id FROM read_csv('${HOST_CACHE}/edges/*.gz', delim='\t', header=false,
    columns={'from_id':'BIGINT','to_id':'BIGINT'})
  WHERE to_id IN (SELECT id FROM target)
)
SELECT
  array_to_string(list_reverse(string_split(v.rev_host, '.')), '.') AS linking_host
FROM inbound i
JOIN vertices v ON v.id = i.from_id
ORDER BY linking_host;
SQL
