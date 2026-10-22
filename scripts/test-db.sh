#!/usr/bin/env bash
# test-db.sh: check the built DB with the grype version the sandboxes run (v0.115.0), side by side with Anchore's
# latest published DB: import time, record counts per provider, and the probe SBOMs in sbom/.
# Writes out/build/report.md, which is also the job summary.
set -euo pipefail
. "$(dirname "$0")/env.sh"
REPO="$PWD"
OUT="$REPO/out/build"
G="$REPO/bin/grype"
export GRYPE_CHECK_FOR_APP_UPDATE=false GRYPE_DB_AUTO_UPDATE=false GRYPE_DB_VALIDATE_AGE=false TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR"
WATCH='["CVE-2026-105481","CVE-2026-105482","CVE-2026-105483","CVE-2026-106069","CVE-2026-106070","CVE-2026-106071","CVE-2026-106072","CVE-2026-106073","CVE-2026-106074","CVE-2026-111497","CVE-2026-109618"]'

# ours
s=$(date +%s)
GRYPE_DB_CACHE_DIR="$WORK/grype-ours" "$G" db import "$OUT"/*.tar.zst >/dev/null
ours_import=$(( $(date +%s) - s ))

# Anchore's latest, checksum from its listing
curl -sSf https://grype.anchore.io/databases/v6/latest.json -o "$OUT/anchore-latest.json"
a_path=$(jq -r .path "$OUT/anchore-latest.json")
a_sum=$(jq -r '.checksum | sub("^sha256:"; "")' "$OUT/anchore-latest.json")
curl -sSfL "https://grype.anchore.io/databases/v6/$a_path" -o "$WORK/anchore.tar.zst"
echo "$a_sum  $WORK/anchore.tar.zst" | sha256sum -c -
GRYPE_DB_CACHE_DIR="$WORK/grype-anchore" "$G" db import "$WORK/anchore.tar.zst" >/dev/null

status() { GRYPE_DB_CACHE_DIR="$1" "$G" db status 2>&1 | sed -n 's/^\(Schema\|Built\|Status\): *//p' | paste -sd' ' -; }
counts() {
  sqlite3 -readonly "$1/6/vulnerability.db" \
    "select p.id, coalesce(p.date_captured,''), (select count(*) from vulnerability_handles v where v.provider_id=p.id) from providers p order by p.id"
}

{
  echo "# grype DB built from sources: bootstrap run"
  echo
  echo "Run: ${GITHUB_SERVER_URL:-local}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"
  echo
  echo "## Provider syncs (no cache)"
  echo
  echo "| provider | start (UTC) | minutes | exit | status | peak memory (MiB) | workspace (MiB) | cache backup (MiB) |"
  echo "|---|---|---|---|---|---|---|---|"
  for f in dl/sync-*/timing.tsv; do
    tail -n +2 "$f" | awk -F'\t' '{printf "| %s | %s | %.1f | %s | %s | %d | %d | %d |\n", $1, $2, $3/60, $4, $5, $6/1048576, $7/1048576, $8/1048576}'
  done | sort
  echo
  echo "Providers left out of the build: $(cat "$OUT/missing-providers.txt")"
  echo
  echo "## Build"
  echo
  echo '```'
  cat "$OUT/timing.tsv"; cat "$OUT/sizes.txt"
  echo "grype v$GRYPE_VERSION import of our DB: ${ours_import}s"
  echo '```'
  echo
  echo "| DB | schema, built, status |"
  echo "|---|---|"
  echo "| ours | $(status "$WORK/grype-ours") |"
  echo "| Anchore latest | $(status "$WORK/grype-anchore") |"
  echo
  echo "## Records per provider"
  echo
  echo "| provider | Anchore captured | Anchore | ours captured | ours | delta |"
  echo "|---|---|---|---|---|---|"
  join -t'|' -a1 -a2 -e- -o 0,1.2,1.3,2.2,2.3 <(counts "$WORK/grype-anchore" | sort) <(counts "$WORK/grype-ours" | sort) \
    | awk -F'|' '{d = ($3 ~ /^[0-9]+$/ && $5 ~ /^[0-9]+$/) ? $5 - $3 : "n/a"; printf "| %s | %s | %s | %s | %s | %s |\n", $1, substr($2,1,19), $3, substr($4,1,19), $5, d}'
  echo
  echo "## Probe SBOMs (grype v$GRYPE_VERSION)"
  echo
  echo "Watched CVEs: the 10 CVEs of the Node.js 2026-10-21 security release, and CVE-2026-109618 (PHP)."
  echo
  echo "| probe | Anchore: all / watched | ours: all / watched | ours: watched by namespace |"
  echo "|---|---|---|---|"
  for sb in sbom/*.cdx.json; do
    n=$(basename "$sb" .cdx.json)
    for db in anchore ours; do
      GRYPE_DB_CACHE_DIR="$WORK/grype-$db" "$G" -q "sbom:$sb" -o json > "$OUT/scan-$db-$n.json"
    done
    a=$(jq -r --argjson w "$WATCH" '"\(.matches|length) / \([.matches[] | select(.vulnerability.id as $i | $w | index($i))] | length)"' "$OUT/scan-anchore-$n.json")
    o=$(jq -r --argjson w "$WATCH" '"\(.matches|length) / \([.matches[] | select(.vulnerability.id as $i | $w | index($i))] | length)"' "$OUT/scan-ours-$n.json")
    ns=$(jq -r --argjson w "$WATCH" '[.matches[] | select(.vulnerability.id as $i | $w | index($i)) | .vulnerability.namespace] | group_by(.) | map("\(.[0])=\(length)") | join(", ")' "$OUT/scan-ours-$n.json")
    echo "| $n | $a | $o | $ns |"
  done
} > "$OUT/report.md"
cat "$OUT/report.md" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
cat "$OUT/report.md"
