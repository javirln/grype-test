#!/usr/bin/env bash
# build-db.sh: restore the provider caches, then grype-db build and package. Writes out/build/.
#   default (bootstrap.yml): the cache tarballs that the sync jobs uploaded (dl/sync-<provider>/). A provider whose
#     sync failed is left out and listed in the report.
#   CACHE_SOURCE=registry (incremental.yml): the caches in the registries (scripts/cache.sh). A provider whose sync
#     succeeded uses the cache its sync job pushed (by digest). A provider whose sync failed uses the newer of our
#     last good cache and Anchore's cache.
set -euo pipefail
. "$(dirname "$0")/env.sh"
REPO="$PWD"
OUT="$REPO/out/build"
mkdir -p "$OUT" "$WORK/data/vunnel"
printf 'step\tseconds\tdetail\n' > "$OUT/timing.tsv"
row() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" | tee -a "$OUT/timing.tsv"; }

present=()
missing=()
s=$(date +%s)
for p in $PROVIDERS; do
  if [ "${CACHE_SOURCE:-artifacts}" = registry ]; then
    t="dl/sync-$p/timing.tsv"
    st=$(awk -F'\t' 'NR==2 {print $5}' "$t" 2>/dev/null || true)
    dg=$(awk -F'\t' 'NR==2 {print $12}' "$t" 2>/dev/null || true)
    if [ "$st" = done ] && [[ $dg == sha256:* ]]; then args=(ours "$dg"); else args=(newer); fi
    echo "restore $p: sync status=${st:-none} -> mode ${args[*]}"
    if OUT="$OUT" "$REPO/scripts/cache.sh" restore "$p" "${args[@]}" >/dev/null; then present+=("$p"); else missing+=("$p"); fi
    continue
  fi
  f="dl/sync-$p/cache-$p.tar.gz"
  if [ -s "$f" ]; then
    (cd "$WORK" && "$REPO/bin/grype-db" -c "$REPO/config/grype-db.yaml" cache restore --path "$REPO/$f" --delete-existing) >/dev/null
    present+=("$p")
  else
    missing+=("$p")
  fi
done
[ ! -f "$OUT/restore.tsv" ] || column -t -s $'\t' "$OUT/restore.tsv"
row restore "$(( $(date +%s) - s ))" "providers=${#present[@]} missing=${missing[*]:-none}"
echo "${missing[*]:-}" > "$OUT/missing-providers.txt"

# build config with the providers that synced
{
  printf 'provider:\n  root: data/vunnel\n  vunnel:\n    generate-configs: false\n  configs:\n'
  for p in "${present[@]}"; do echo "    - name: $p"; done
  sed -n '/^build:/,$p' config/grype-db.yaml
} > "$WORK/grype-db.yaml"
cat "$WORK/grype-db.yaml"
du -sh "$WORK/data/vunnel" | tee -a "$OUT/sizes.txt"
df -h / /mnt

# host memory and swap peaks while grype-db runs (the RSS of grype-db alone is in maxrss_kb)
memwatch() {
  local used swap mu=0 ms=0
  while :; do
    read -r used swap < <(awk '/^MemTotal/ {t=$2} /^MemAvailable/ {a=$2} /^SwapTotal/ {st=$2} /^SwapFree/ {sf=$2} END {print t-a, st-sf}' /proc/meminfo)
    (( used > mu )) && mu=$used; (( swap > ms )) && ms=$swap
    echo "mem_used_peak_kb=$mu swap_used_peak_kb=$ms" > "$1"
    sleep 5
  done
}
s=$(date +%s)
memwatch "$OUT/mem-build.txt" & mw=$!
(cd "$WORK" && rm -rf build && /usr/bin/time -v "$REPO/bin/grype-db" -c grype-db.yaml build) > "$OUT/build.log" 2> "$OUT/build.err"
kill "$mw"
row build "$(( $(date +%s) - s ))" "maxrss_kb=$(awk -F': ' '/Maximum resident/ {print $2}' "$OUT/build.err") $(cat "$OUT/mem-build.txt")"
s=$(date +%s)
memwatch "$OUT/mem-package.txt" & mw=$!
(cd "$WORK" && /usr/bin/time -v "$REPO/bin/grype-db" -c grype-db.yaml package) > "$OUT/package.log" 2> "$OUT/package.err"
kill "$mw"
row package "$(( $(date +%s) - s ))" "$(basename "$WORK"/build/*.tar.zst) bytes=$(stat -c %s "$WORK"/build/*.tar.zst) maxrss_kb=$(awk -F': ' '/Maximum resident/ {print $2}' "$OUT/package.err") $(cat "$OUT/mem-package.txt")"
cp "$WORK"/build/latest.json "$OUT/"
# the archive name has colons (its date), which actions/upload-artifact rejects: copy it without them
for f in "$WORK"/build/*.tar.zst; do b=$(basename "$f"); cp "$f" "$OUT/${b//:/-}"; done
df -h / /mnt
