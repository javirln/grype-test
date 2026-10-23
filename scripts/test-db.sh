#!/usr/bin/env bash
# test-db.sh: check the built DB with the grype version the sandboxes run (v0.115.0), side by side with Anchore's
# latest published DB: import time, freshness (date_captured) and record counts per provider, the vulnerability
# IDs of Anchore's DB that ours misses (the gate: fail a provider above 1% missing), archive sizes, and the probe
# SBOMs in sbom/. With CACHE_SOURCE=registry (incremental.yml) it also reports the cache flow: which cache each
# sync job and the build restored, what each sync job pushed, and our caches now in the registry.
# Writes out/build/report.md, which is also the job summary.
set -euo pipefail
. "$(dirname "$0")/env.sh"
REPO="$PWD"
OUT="$REPO/out/build"
G="$REPO/bin/grype"
INCR=0; [ "${CACHE_SOURCE:-artifacts}" = registry ] && INCR=1
GATE_PCT="${GATE_PCT:-1}"
export GRYPE_CHECK_FOR_APP_UPDATE=false GRYPE_DB_AUTO_UPDATE=false GRYPE_DB_VALIDATE_AGE=false TMPDIR="$WORK/tmp"
export SQLITE_TMPDIR="$WORK/tmp" LC_ALL=C   # one sort order for sort and join
mkdir -p "$TMPDIR"
WATCH='["CVE-2026-105481","CVE-2026-105482","CVE-2026-105483","CVE-2026-106069","CVE-2026-106070","CVE-2026-106071","CVE-2026-106072","CVE-2026-106073","CVE-2026-106074","CVE-2026-111497","CVE-2026-109618"]'
printf 'step\tseconds\n' > "$OUT/check-timing.tsv"
crow() { printf '%s\t%s\n' "$1" "$2" | tee -a "$OUT/check-timing.tsv"; }
check_start=$(date +%s)

# ours
ours_tar=$(ls "$OUT"/*.tar.zst)
s=$(date +%s)
GRYPE_DB_CACHE_DIR="$WORK/grype-ours" "$G" db import "$ours_tar" >/dev/null
ours_import=$(( $(date +%s) - s )); crow import-ours "$ours_import"

# Anchore's latest, checksum from its listing
s=$(date +%s)
curl -sSf https://grype.anchore.io/databases/v6/latest.json -o "$OUT/anchore-latest.json"
a_path=$(jq -r .path "$OUT/anchore-latest.json")
a_sum=$(jq -r '.checksum | sub("^sha256:"; "")' "$OUT/anchore-latest.json")
curl -sSfL "https://grype.anchore.io/databases/v6/$a_path" -o "$WORK/anchore.tar.zst"
echo "$a_sum  $WORK/anchore.tar.zst" | sha256sum -c -
GRYPE_DB_CACHE_DIR="$WORK/grype-anchore" "$G" db import "$WORK/anchore.tar.zst" >/dev/null
crow download-and-import-anchore "$(( $(date +%s) - s ))"

status() { GRYPE_DB_CACHE_DIR="$1" "$G" db status 2>&1 | sed -n 's/^\(Schema\|Built\|Status\): *//p' | paste -sd' ' -; }
captured() {
  sqlite3 -readonly "$1/6/vulnerability.db" "select id, coalesce(date_captured,'') from providers order by id"
}

# One ID set per provider: vulnerability names, plus the CVEs of kev and epss and the OS releases of eol, which
# grype-db v6 keeps in their own tables.
ids_sql() {   # ids_sql <schema>
  cat <<EOF
select provider_id, name from $1.vulnerability_handles
union select 'kev', cve from $1.known_exploited_vulnerability_handles
union select 'epss', cve from $1.epss_handles
union select 'eol', name || ' ' || coalesce(major_version,'') || '.' || coalesce(minor_version,'') || ' ' ||
             coalesce(label_version,'') || ' ' || coalesce(channel,'')
      from $1.operating_systems where eol_date is not null or eoas_date is not null
EOF
}
s=$(date +%s)
sqlite3 :memory: > "$OUT/id-diff.tsv" <<EOF
attach 'file:$WORK/grype-anchore/6/vulnerability.db?mode=ro' as a;
attach 'file:$WORK/grype-ours/6/vulnerability.db?mode=ro' as o;
create temp table ia as $(ids_sql a);
create temp table io as $(ids_sql o);
create temp table miss as select * from ia except select * from io;
create temp table extra as select * from io except select * from ia;
.mode tabs
.headers on
select p as provider, sum(k='a') as anchore_ids, sum(k='o') as our_ids, sum(k='m') as missing_from_ours, sum(k='x') as extra_in_ours
from (select provider_id p, 'a' k from ia union all select provider_id, 'o' from io
      union all select provider_id, 'm' from miss union all select provider_id, 'x' from extra)
group by p order by p;
.output $OUT/missing-ids.tsv
select * from miss order by 1, 2;
.output $OUT/extra-ids.tsv
select * from extra order by 1, 2;
EOF
crow id-diff "$(( $(date +%s) - s ))"

a_bytes=$(stat -c %s "$WORK/anchore.tar.zst"); o_bytes=$(stat -c %s "$ours_tar")
mib() { awk -v b="$1" 'BEGIN {printf "%.1f", b/1048576}'; }
hours() { awk -v s="$1" 'BEGIN {printf "%.1f", s/3600}'; }

sync_table_bootstrap() {
  echo "| provider | start (UTC) | minutes | exit | status | peak memory (MiB) | workspace (MiB) | cache backup (MiB) |"
  echo "|---|---|---|---|---|---|---|---|"
  for f in dl/sync-*/timing.tsv; do
    tail -n +2 "$f" | awk -F'\t' '{printf "| %s | %s | %.1f | %s | %s | %d | %d | %d |\n", $1, $2, $3/60, $4, $5, $6/1048576, $7/1048576, $8/1048576}'
  done | sort
}

sync_table_incremental() {
  echo "| provider | restored from | cache digest | cache created | age (h) | fetch+restore (s) | vunnel (min) | exit | status | peak mem (MiB) | workspace (MiB) | backup (MiB) | results before → after | pushed digest | push (s) |"
  echo "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"
  for p in $PROVIDERS; do
    r="dl/sync-$p/restore.tsv" t="dl/sync-$p/timing.tsv"
    IFS=$'\t' read -r _ _ src mdg created age _ _ _ _ _ < <(tail -n +2 "$r" 2>/dev/null || echo)
    IFS=$'\t' read -r _ _ secs rc st peak ws bk rs before after pushed push_s < <(tail -n +2 "$t" 2>/dev/null || echo)
    printf '| %s | %s | `%s` | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s → %s | `%s` | %s |\n' "$p" "${src:--}" "${mdg:7:12}" \
      "${created:--}" "$(hours "${age:-0}")" "${rs:--}" "$(awk -v s="${secs:-0}" 'BEGIN {printf "%.1f", s/60}')" "${rc:--}" \
      "${st:-no result}" "$(( ${peak:-0} / 1048576 ))" "$(( ${ws:-0} / 1048576 ))" "$(mib "${bk:-0}")" "${before:--}" "${after:--}" \
      "$([[ ${pushed:-} == sha256:* ]] && echo "${pushed:7:12}" || echo "not pushed")" "${push_s:--}"
  done
}

build_restore_table() {
  echo "| provider | build mode | restored from | cache digest | cache created | our latest created | Anchore latest created |"
  echo "|---|---|---|---|---|---|---|"
  tail -n +2 "$OUT/restore.tsv" | awk -F'\t' '{printf "| %s | %s | %s | `%s` | %s | %s | %s |\n", $1, ($2=="ours" ? "ours@digest (sync ok)" : "newer (sync failed)"), $3, substr($4,8,12), $5, $10, $11}'
}

registry_table() {
  local total_o=0 total_a=0 p om am od oc ob ab
  echo "| provider | our latest digest | created | our size (MiB) | Anchore size (MiB) |"
  echo "|---|---|---|---|---|"
  for p in $PROVIDERS; do
    om=$("$REPO/scripts/cache.sh" meta ours "$p" latest 2>/dev/null || true)
    am=$("$REPO/scripts/cache.sh" meta anchore "$p" latest 2>/dev/null || true)
    IFS=$'\t' read -r od oc _ ob <<<"${om:-}"; ab=$(cut -f4 <<<"${am:-}")
    total_o=$(( total_o + ${ob:-0} )); total_a=$(( total_a + ${ab:-0} ))
    printf '| %s | `%s` | %s | %s | %s |\n' "$p" "${od:--}" "${oc:--}" "$(mib "${ob:-0}")" "$(mib "${ab:-0}")"
  done
  printf '| **total** | | | **%s** | **%s** |\n' "$(mib $total_o)" "$(mib $total_a)"
}

{
  if [ "$INCR" = 1 ]; then
    echo "# grype DB built incrementally from provider caches"
  else
    echo "# grype DB built from sources: bootstrap run"
  fi
  echo
  echo "Run: ${GITHUB_SERVER_URL:-local}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"
  [ -z "${FAIL_PROVIDER:-}" ] || echo "Provider failed on purpose (no network for its vunnel run): \`$FAIL_PROVIDER\`"
  echo
  if [ "$INCR" = 1 ]; then
    echo "## Sync jobs: restore, vunnel on top, back up, push only on success"
    echo
    sync_table_incremental
    echo
    echo "## Caches the build restored"
    echo
    build_restore_table
    echo
    echo "## Our caches in the registry after this run (\`$CACHE_REPO/<provider>:latest\`)"
    echo
    registry_table
  else
    echo "## Provider syncs (no cache)"
    echo
    sync_table_bootstrap
  fi
  echo
  echo "Providers left out of the build: $(cat "$OUT/missing-providers.txt")"
  echo
  echo "## Build"
  echo
  echo '```'
  cat "$OUT/timing.tsv"; cat "$OUT/sizes.txt"
  echo "archive bytes: ours=$o_bytes ($(mib "$o_bytes") MiB) Anchore=$a_bytes ($(mib "$a_bytes") MiB) $a_path"
  cat "$OUT/check-timing.tsv"
  echo '```'
  echo
  echo "| DB | schema, built, status |"
  echo "|---|---|"
  echo "| ours | $(status "$WORK/grype-ours") |"
  echo "| Anchore latest | $(status "$WORK/grype-anchore") |"
  echo
  echo "## Freshness and the ID gate per provider"
  echo
  echo "IDs: vulnerability names (kev, epss: CVEs; eol: OS releases). Missing: IDs in Anchore's DB that ours does not have. Gate: fail a provider above ${GATE_PCT}% missing."
  echo
  echo "| provider | Anchore captured | ours captured | Anchore IDs | our IDs | missing from ours | missing % | extra in ours | gate |"
  echo "|---|---|---|---|---|---|---|---|---|"
  join -t $'\t' -a1 -a2 -e- -o 0,1.2,1.3,1.4,1.5,2.2,2.3 \
      <(tail -n +2 "$OUT/id-diff.tsv" | sort -t $'\t' -k1,1) \
      <(join -t '|' -a1 -a2 -e- -o 0,1.2,2.2 <(captured "$WORK/grype-anchore" | sort -t '|' -k1,1) \
              <(captured "$WORK/grype-ours" | sort -t '|' -k1,1) | tr '|' '\t') \
    | awk -F'\t' -v gate="$GATE_PCT" '{
        pct = ($2 ~ /^[0-9]+$/ && $2 > 0 && $4 ~ /^[0-9]+$/) ? 100 * $4 / $2 : 0
        verdict = ($3 == "-" || $3 == 0) && $2 > 0 ? "FAIL (absent)" : (pct > gate ? "FAIL" : "pass")
        printf "| %s | %s | %s | %s | %s | %s | %.2f | %s | %s |\n", $1, substr($6,1,19), substr($7,1,19), $2, $3, $4, pct, $5, verdict
      }' | tee "$OUT/gate.md"
  echo
  echo "Gate: $(grep -c 'FAIL' "$OUT/gate.md" || true) of $(grep -c '^|' "$OUT/gate.md") providers fail: $(awk -F' [|] ' '/FAIL/ {sub(/^\| /, "", $1); printf "%s ", $1}' "$OUT/gate.md")"
  echo
  echo "Lists: \`missing-ids.tsv\`, \`extra-ids.tsv\` in the run artifact."
  echo
  echo "## Probe SBOMs (grype v$GRYPE_VERSION)"
  echo
  echo "Watched CVEs: the 10 CVEs of the Node.js 2026-10-21 security release, and CVE-2026-109618 (PHP)."
  echo
  echo "| probe | Anchore: all / watched | ours: all / watched | ours: watched by namespace |"
  echo "|---|---|---|---|"
  s=$(date +%s)
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
  echo
  echo "Probe scans: $(( $(date +%s) - s ))s. Whole check: $(( $(date +%s) - check_start ))s."
} > "$OUT/report.md"
cat "$OUT/report.md" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
cat "$OUT/report.md"
