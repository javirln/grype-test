#!/usr/bin/env bash
# build-db.sh: restore the provider caches that the sync jobs produced (dl/sync-<provider>/), then grype-db build
# and package. A provider whose sync failed is left out and listed in the report. Writes out/build/.
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
  f="dl/sync-$p/cache-$p.tar.gz"
  if [ -s "$f" ]; then
    (cd "$WORK" && "$REPO/bin/grype-db" -c "$REPO/config/grype-db.yaml" cache restore --path "$REPO/$f" --delete-existing) >/dev/null
    present+=("$p")
  else
    missing+=("$p")
  fi
done
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

s=$(date +%s)
(cd "$WORK" && rm -rf build && /usr/bin/time -v "$REPO/bin/grype-db" -c grype-db.yaml build) > "$OUT/build.log" 2> "$OUT/build.err"
row build "$(( $(date +%s) - s ))" "maxrss_kb=$(awk -F': ' '/Maximum resident/ {print $2}' "$OUT/build.err")"
s=$(date +%s)
(cd "$WORK" && "$REPO/bin/grype-db" -c grype-db.yaml package) > "$OUT/package.log" 2>&1
row package "$(( $(date +%s) - s ))" "$(basename "$WORK"/build/*.tar.zst) bytes=$(stat -c %s "$WORK"/build/*.tar.zst)"
cp "$WORK"/build/latest.json "$WORK"/build/*.tar.zst "$OUT/"
df -h / /mnt
